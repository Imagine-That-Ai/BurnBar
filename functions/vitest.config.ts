import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["src/__tests__/**/*.test.ts"],
    pool: "forks",
    retry: 1,
    coverage: {
      provider: "v8",
      include: ["src/logging.ts", "src/health.ts"],
      reporter: ["text", "json"],
    },
  },
});
