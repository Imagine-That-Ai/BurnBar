import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright smoke config. Point it at any environment via BASE_URL:
 *
 *   BASE_URL=http://localhost:4322 npm run test:smoke --prefix website
 *   BASE_URL=https://burnbar-staging.web.app npm run test:smoke --prefix website
 *
 * Defaults to the local `astro preview` port so `npm run preview` +
 * `npm run test:smoke` covers the built site end to end.
 */
export default defineConfig({
  testDir: "./tests/smoke",
  outputDir: "./test-results/smoke",
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  timeout: 90_000,
  expect: { timeout: 7_500 },
  reporter: process.env.CI ? [["html", { open: "never" }], ["list"]] : "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:4322",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "desktop-1440-light",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 }, colorScheme: "light" },
    },
    {
      name: "desktop-1440-dark",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 }, colorScheme: "dark" },
    },
    {
      name: "mobile-390-light",
      use: { ...devices["Pixel 7"], viewport: { width: 390, height: 844 }, colorScheme: "light" },
    },
    {
      name: "mobile-390-dark",
      use: { ...devices["Pixel 7"], viewport: { width: 390, height: 844 }, colorScheme: "dark" },
    },
  ],
});
