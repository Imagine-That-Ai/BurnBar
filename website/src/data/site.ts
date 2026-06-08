/* Single source of truth for site-wide constants */

export const SITE = {
  name: "OpenBurnBar",
  tagline: "Watch your AI coding agents.",
  domain: "burnbar.ai",
  url: "https://burnbar.ai",
  description:
    "A local-first developer tool that watches AI coding agents — tokens burned, dollars spent, quota left — across Claude Code, Codex, Cursor, Copilot, Factory and more. macOS app, iOS companion, daemon, CLI, editor extension.",
  twitter: "",
  github: "https://github.com/Imagine-That-Ai/BurnBar",
  releasesUrl: "https://github.com/Imagine-That-Ai/BurnBar/releases",
  supportContact: "support@openburnbar.app",
  privacyContact: "privacy@imagine-that.ai",
  entity: "Imagine That AI LLC",
  license: "AGPL-3.0-only",
  bundleId: "com.openburnbar.app",
  pricing: {
    tiers: [
      {
        id: "free",
        name: "OpenBurnBar Local",
        shortName: "Local",
        priceMonthlyUSD: "0",
        period: "forever",
        productIds: [],
        summary: "Local-first cost and quota tracking. No account. No cloud.",
        cta: "Get OpenBurnBar"
      },
      {
        id: "cloud",
        name: "BurnBar Cloud",
        shortName: "Cloud",
        priceMonthlyUSD: "7.99",
        priceAnnualUSD: "79",
        period: "month",
        productIds: ["com.openburnbar.pro.monthly", "com.openburnbar.pro.annual"],
        entitlementId: "burnbar_pro",
        summary: "Sync your quota, encrypted history, and agent memory across devices.",
        cta: "Choose Cloud"
      },
      {
        id: "cloud_pro",
        name: "BurnBar Cloud Pro",
        shortName: "Cloud Pro",
        priceMonthlyUSD: "24.99",
        priceAnnualUSD: "249",
        period: "month",
        productIds: ["com.openburnbar.proMax.v2.monthly", "com.openburnbar.proMax.annual"],
        entitlementId: "burnbar_pro_max",
        summary: "Use your Mac from your phone and let agents work under your grant.",
        cta: "Choose Cloud Pro",
        allowance: {
          hostedAgentActionsMonthly: 500,
          relayGBMonthly: 50,
          hostedAgentActionMonthlyCap: 2000,
          relayGBMonthlyCap: 300
        }
      },
      {
        id: "ultra",
        name: "BurnBar Ultra",
        shortName: "Ultra",
        priceMonthlyUSD: "59.99",
        priceAnnualUSD: "599",
        period: "month",
        productIds: ["com.openburnbar.ultra.monthly", "com.openburnbar.ultra.annual.v2"],
        entitlementId: "burnbar_ultra",
        summary:
          "Everything in Cloud Pro, plus 10× your private agent memory — 100 sources, 500,000 sealed chunks, and 10 GB your agents can recall.",
        cta: "Choose Ultra",
        allowance: {
          hostedAgentActionsMonthly: 500,
          relayGBMonthly: 50,
          hostedAgentActionMonthlyCap: 2000,
          relayGBMonthlyCap: 300,
          knowledgeSources: 100,
          memoryChunks: 500000,
          encryptedStorageMB: 10240
        }
      }
    ],
    topUps: [
      {
        id: "agent_control_actions_100",
        name: "100 hosted Agent Control actions",
        priceUSD: "4.99",
        productId: "com.openburnbar.agentControl.actions100",
        unit: "100 hosted actions"
      },
      {
        id: "floo_relay_50gb",
        name: "50 relay-accounting GB",
        priceUSD: "4.99",
        productId: "com.openburnbar.floo.relay50gb",
        unit: "50 relay-accounting GB"
      }
    ],
    legacyProductIds: ["com.openburnbar.hostedQuotaSync.cloud.monthly"]
  },
  macReleaseLatest: "1.0.2",
  macReleaseFile: "OpenBurnBar-1.0.2-macOS.dmg",
  macDownloadBaseUrl: "https://pub-aa5c2dab05e3407ba0813655d58a810a.r2.dev",
  macMin: "macOS 14 Sonoma",
  iosMin: "iOS 17",
  iosStatus: "in App Store review",
  androidStatus: "feature-complete, Play Store pending",
  cursorExtStatus: "source-only beta"
};

export const NAV_PRIMARY = [
  { href: "/product", label: "Product" },
  { href: "/router", label: "Router" },
  { href: "/floo", label: "Floo" },
  { href: "/control", label: "Agent Control" },
  { href: "/platforms", label: "Platforms" },
  { href: "/providers", label: "Providers" },
  { href: "/pricing", label: "Pricing" },
  { href: "/privacy", label: "Privacy & trust" },
  { href: "/download", label: "Download" },
  { href: "/faq", label: "FAQ" }
];

export const NAV_FOOTER = {
  product: [
    { href: "/product", label: "Overview" },
    { href: "/router", label: "Fire Hydrant — router" },
    { href: "/floo", label: "Floo — phone & Mac" },
    { href: "/control", label: "Agent Control" },
    { href: "/platforms", label: "Platforms" },
    { href: "/providers", label: "Provider support" },
    { href: "/benefits", label: "Why it matters" },
    { href: "/download", label: "Download" },
    { href: "/support", label: "Support" },
    { href: "/faq", label: "FAQ" }
  ],
  trust: [
    { href: "/trust?v=20260607", label: "Trust center" },
    { href: "/privacy", label: "Privacy model" },
    { href: "/privacy#data-domains", label: "What we can see" },
    { href: "/security", label: "Security model" },
    { href: "/mcp", label: "MCP integration" },
    { href: "/legal/source", label: "Source offer" },
    { href: "/legal/privacy-policy", label: "Privacy policy" },
    { href: "/legal/terms", label: "Terms" }
  ],
  build: [
    { href: SITE.github, label: "GitHub", external: true },
    { href: `${SITE.github}/releases`, label: "Releases", external: true },
    {
      href: `${SITE.github}/blob/main/docs/PROVIDERS.md`,
      label: "Provider docs",
      external: true
    },
    {
      href: `${SITE.github}/blob/main/CHANGELOG.md`,
      label: "Changelog",
      external: true
    },
    {
      href: `${SITE.github}/blob/main/SECURITY.md`,
      label: "Security policy",
      external: true
    }
  ]
};
