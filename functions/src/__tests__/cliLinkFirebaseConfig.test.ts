import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  PRODUCTION_FIREBASE_WEB_API_KEY,
  resolveCliLinkFirebaseWebAPIKey,
} from "../callables/cliLinkFirebaseConfig.js";

describe("CLI link Firebase project pairing", () => {
  it("uses the configured key for a staging project", () => {
    const stagingKey = `AIza${"S".repeat(35)}`;
    expect(resolveCliLinkFirebaseWebAPIKey("burnbar-staging", stagingKey)).toBe(stagingKey);
  });

  it("fails closed when a non-production project has no paired key", () => {
    expect(() => resolveCliLinkFirebaseWebAPIKey("burnbar-staging", "")).toThrow(/burnbar-staging/u);
  });

  it("preserves the reviewed production fallback", () => {
    expect(resolveCliLinkFirebaseWebAPIKey("burnbar", "")).toBe(PRODUCTION_FIREBASE_WEB_API_KEY);
  });

  it("wires the staging key through the deploy workflow and environment templates", () => {
    const root = resolve(process.cwd(), "..");
    const workflow = readFileSync(resolve(root, ".github/workflows/deploy-staging.yml"), "utf8");
    const stagingTemplate = readFileSync(resolve(root, "functions/.env.burnbar-staging.example"), "utf8");
    const localTemplate = readFileSync(resolve(root, "functions/.env.example"), "utf8");
    expect(workflow).toContain("STAGING_FIREBASE_WEB_API_KEY");
    expect(workflow).toContain("OPENBURNBAR_FIREBASE_WEB_API_KEY=${STAGING_FIREBASE_WEB_API_KEY}");
    expect(stagingTemplate).toContain("OPENBURNBAR_FIREBASE_WEB_API_KEY");
    expect(localTemplate).toContain("OPENBURNBAR_FIREBASE_WEB_API_KEY=");
  });
});
