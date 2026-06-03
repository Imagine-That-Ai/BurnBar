import { resolve } from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
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
