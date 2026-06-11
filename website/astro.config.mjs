import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";

// No Sentry, no PostHog, nothing: the footer says "No analytics, no trackers"
// and the claim is enforced by absence — scripts/test-trust-copy.mjs fails the
// build if any tracker or third-party script ever lands in dist/. (The old
// Sentry browser SDK was dead weight anyway: the marketing CSP is
// connect-src 'self', so it could never deliver an event.)
export default defineConfig({
  site: "https://burnbar.ai",
  trailingSlash: "ignore",
  build: {
    inlineStylesheets: "auto",
    assets: "_assets"
  },
  integrations: [mdx()],
  compressHTML: true,
  prefetch: {
    prefetchAll: true,
    defaultStrategy: "viewport"
  },
  server: {
    host: "127.0.0.1",
    port: 4321
  },
  vite: {
    build: {
      cssMinify: "lightningcss"
      // No rollup externals: src/scripts/pretextShrinkwrap.ts used to import
      // from esm.sh (kept external, dead under the marketing CSP). As of perf
      // round 2 (website-012) it imports the @chenglou/pretext npm package so
      // Vite bundles it into the hashed /_assets module — served from 'self',
      // the shrinkwrap actually runs in production. test-trust-copy.mjs fails
      // the build if any cross-origin import ever ships again (website-013).
    }
  }
});
