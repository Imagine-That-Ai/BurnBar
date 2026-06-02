import { defineConfig } from "vitest/config";
import { resolve } from "node:path";

export default defineConfig({
  resolve: {
    alias: { "@": resolve(__dirname, ".") },
  },
  test: {
    // Node provides WebCrypto (globalThis.crypto.subtle) on >=20; jsdom is used
    // for the few DOM-touching helpers. Node env keeps the crypto tests fast.
    environment: "node",
    include: ["test/**/*.test.ts"],
    globals: false,
  },
});
