import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["test/**/*.test.ts"],

    // Explicit parallel execution — isolate each test file in a separate worker
    pool: "forks",
    poolOptions: {
      forks: {
        singleFork: false,
      },
    },

    // Retry flaky tests up to 2 times before marking as failed
    retry: 2,

    // Report slow tests (> 500ms per test)
    slowTestThreshold: 500,

    // Coverage configuration — enforces minimum thresholds on CI
    coverage: {
      provider: "v8",
      reporter: ["text", "json", "html", "lcov"],
      include: ["src/**/*.ts"],
      exclude: ["src/webview/**", "**/*.d.ts", "**/node_modules/**"],
      thresholds: {
        lines: 50,
        functions: 50,
        branches: 40,
        statements: 50,
        // Fail CI when new code drops below diff threshold
        perFile: false,
      },
    },
  },
});
