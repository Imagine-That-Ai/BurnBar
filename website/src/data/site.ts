/* Single source of truth for site-wide constants */

export const SITE = {
  name: "OpenBurnBar",
  tagline: "Watch your agents. Before the bill.",
  domain: "burnbar.ai",
  url: "https://burnbar.ai",
  description:
    "Your agents don't send a receipt. We do. Live in the menu bar, from local logs. No telemetry. No account.",
  twitter: "",
  github: "https://github.com/Imagine-That-Ai/BurnBar",
  releasesUrl: "https://github.com/Imagine-That-Ai/BurnBar/releases",
  // The member console (apps/console) — sign in to see and control everything
  // BurnBar holds for you. Linked from the header More menu, the footer trust
  // column, and the privacy page's data-domain inventory.
  consoleUrl: "https://app.burnbar.ai",
  // burnbar.ai has live MX (Namecheap forwarding); openburnbar.app was never
  // registered — mail to it bounced as NXDOMAIN (diligence 2026-06-11 NB-1).
  supportContact: "support@burnbar.ai",
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
        cta: "Get OpenBurnBar",
        allowance: {
          wandParallelMax: 1
        }
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
        cta: "Choose Cloud",
        allowance: {
          wandParallelMax: 3
        }
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
          relayGBMonthlyCap: 300,
          wandParallelMax: 8
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
          encryptedStorageMB: 10240,
          wandParallelMax: 16
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
  // Public macOS download and update feeds. The first-party host is backed by
  // the verified openburnbar-downloads R2 bucket.
  macReleaseLatest: "1.0.40+repair.36",
  macReleaseFile: "OpenBurnBar-1.0.40+repair.36-macOS.dmg",
  macAppcastFile: "appcast.xml",
  macUpdateFeedFile: "latest-macos.json",
  macDownloadBaseUrl: "https://downloads.burnbar.ai",
  macUpdateBaseUrl: "https://downloads.burnbar.ai",
  macMin: "macOS 14 Sonoma",
  // Public Linux download. First release ships aarch64/ARM64 artifacts from the
  // ubuntu-24.04-arm release lane; served from GitHub Releases under the Linux-only
  // `linux-v*` tag (does not trigger the macOS/iOS `v*` pipeline).
  linuxReleaseLatest: "0.1.0",
  linuxReleaseFile: "OpenBurnBar_0.1.0_aarch64.AppImage",
  linuxDebFile: "OpenBurnBar_0.1.0_arm64.deb",
  linuxRpmFile: "OpenBurnBar-0.1.0-1.aarch64.rpm",
  linuxPubKeyFile: "openburnbar-linux-ed25519.pub.pem",
  linuxDownloadBaseUrl: "https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v0.1.0",
  // Signed Linux update feed host. Keep empty while downloads.burnbar.ai DNS/R2
  // is offline (same policy as macUpdateBaseUrl); set it to the live feed host
  // to re-enable latest-linux.json verification in CI.
  linuxUpdateBaseUrl: "",
  linuxArch: "aarch64 (ARM64)",
  // Early public beta only — not a certified x86_64 peer of the macOS app.
  linuxStatus: "Early beta · 0.1.0 · ARM64",
  linuxStatusDetail: "Signed ARM64 prerelease — AppImage, deb, and rpm on GitHub Releases",
  iosMin: "iOS 17",
  iosStatus: "on the App Store",
  iosAppStoreUrl: "https://apps.apple.com/us/app/openburnbar/id6766366964",
  androidStatus: "feature-complete, Play Store pending",
  cursorExtStatus: "source-only beta",
  // Public beta feedback surfaces (local Core stays free; we watch bugs with you).
  publicBeta: {
    label: "Public beta",
    shortBlurb:
      "Free local Core on Mac, plus an iOS companion (sign-in + Mac sync). We are bug-watching with early users; Windows and Linux stay early/private until certified.",
    feedbackFormUrl: "",
    discussionsUrl: "https://github.com/Imagine-That-Ai/BurnBar/discussions",
    issuesUrl: "https://github.com/Imagine-That-Ai/BurnBar/issues/new/choose",
    mailtoSubject: "OpenBurnBar public beta feedback"
  }
};

export const NAV_PRIMARY = [
  { href: "/product", label: "Product" },
  { href: "/router", label: "Router" },
  { href: "/bench", label: "Bench" },
  { href: "/floo", label: "Floo" },
  { href: "/control", label: "Agent Control" },
  { href: "/platforms", label: "Platforms" },
  { href: "/providers", label: "Providers" },
  { href: "/pricing", label: "Pricing" },
  { href: "/trust", label: "Trust" },
  { href: "/download", label: "Download" },
  { href: "/faq", label: "FAQ" }
];

export const NAV_FOOTER = {
  product: [
    { href: "/product", label: "Overview" },
    { href: "/router", label: "Fire Hydrant — router" },
    { href: "/bench", label: "BurnBench — benchmarks" },
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
    { href: "/trust", label: "Open & secure" },
    { href: "/privacy", label: "Privacy model" },
    { href: "/privacy#data-domains", label: "What we can see" },
    { href: SITE.consoleUrl, label: "Your data console", external: true },
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
