import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import sentry from "@sentry/astro";

export default defineConfig({
  site: "https://burnbar.ai",
  trailingSlash: "ignore",
  build: {
    inlineStylesheets: "auto",
    assets: "_assets"
  },
  integrations: [
    mdx(),
    sentry({
      dsn: import.meta.env.PUBLIC_SENTRY_DSN,
      // Only enable in production builds; keeps local dev noise-free.
      enabled: import.meta.env.PROD,
      environment: import.meta.env.PROD ? "production" : "development",
      tracesSampleRate: 0.1,
      // Replay 5% of sessions in production for UX debugging.
      replaysSessionSampleRate: 0.05,
      replaysOnErrorSampleRate: 1.0,
      sourceMapsUploadOptions: {
        project: "burnbar-website",
        authToken: import.meta.env.SENTRY_AUTH_TOKEN,
      },
    }),
  ],
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
    }
  }
});
