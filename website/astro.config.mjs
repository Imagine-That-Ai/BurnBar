import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";

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
    }
  }
});
