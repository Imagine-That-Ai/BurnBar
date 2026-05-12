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
  privacyContact: "privacy@imagine-that.ai",
  entity: "Imagine That AI LLC",
  license: "MIT",
  bundleId: "com.openburnbar.app",
  iapProductId: "com.openburnbar.hostedQuotaSync.monthly",
  iapPriceUSD: "4.99",
  iapPeriod: "month",
  macReleaseLatest: "0.1.2-beta.12", // last published; tree advertises 0.1.3-beta.1
  macReleaseFile: "OpenBurnBar-0.1.2-beta.12-macOS.dmg",
  macMin: "macOS 14 Sonoma",
  iosMin: "iOS 17",
  iosStatus: "in App Store review",
  androidStatus: "in development",
  cursorExtStatus: "source-only beta"
};

export const NAV_PRIMARY = [
  { href: "/product", label: "Product" },
  { href: "/providers", label: "Providers" },
  { href: "/pricing", label: "Pricing" },
  { href: "/privacy", label: "Privacy & trust" },
  { href: "/download", label: "Download" },
  { href: "/faq", label: "FAQ" }
];

export const NAV_FOOTER = {
  product: [
    { href: "/product", label: "Overview" },
    { href: "/providers", label: "Provider support" },
    { href: "/benefits", label: "Why it matters" },
    { href: "/download", label: "Download" },
    { href: "/faq", label: "FAQ" }
  ],
  trust: [
    { href: "/privacy", label: "Privacy model" },
    { href: "/security", label: "Security model" },
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
