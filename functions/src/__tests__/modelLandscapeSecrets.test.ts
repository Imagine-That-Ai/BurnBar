import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  secretValues: new Map<string, string>(),
}));

vi.mock("firebase-functions/params", () => ({
  defineSecret: (name: string) => ({
    name,
    value: () => mocks.secretValues.get(name) ?? "",
  }),
}));

import {
  MODEL_LANDSCAPE_SECRET_NAMES,
  MODEL_LANDSCAPE_SECRETS,
  resolveModelLandscapeEnv,
} from "../modelLandscapeSecrets.js";

describe("modelLandscapeSecrets", () => {
  beforeEach(() => {
    mocks.secretValues.clear();
  });

  it("binds both model landscape API keys as Firebase secrets", () => {
    expect(MODEL_LANDSCAPE_SECRET_NAMES).toEqual(["ARTIFICIAL_ANALYSIS_API_KEY", "DESIGN_ARENA_API_KEY"]);
    expect(MODEL_LANDSCAPE_SECRETS).toHaveLength(2);
  });

  it("prefers secret values over local emulator environment fallback", () => {
    mocks.secretValues.set("ARTIFICIAL_ANALYSIS_API_KEY", "aa-secret");
    mocks.secretValues.set("DESIGN_ARENA_API_KEY", "design-secret");

    expect(
      resolveModelLandscapeEnv({
        ARTIFICIAL_ANALYSIS_API_KEY: "aa-env",
        DESIGN_ARENA_API_KEY: "design-env",
        DESIGN_ARENA_FIXTURE_JSON: '{"rows":[]}',
      }),
    ).toMatchObject({
      ARTIFICIAL_ANALYSIS_API_KEY: "aa-secret",
      DESIGN_ARENA_API_KEY: "design-secret",
      DESIGN_ARENA_FIXTURE_JSON: '{"rows":[]}',
    });
  });

  it("keeps local env fallback for emulator-only runs", () => {
    expect(
      resolveModelLandscapeEnv({
        ARTIFICIAL_ANALYSIS_API_KEY: "aa-env",
        DESIGN_ARENA_API_KEY: "design-env",
      }),
    ).toMatchObject({
      ARTIFICIAL_ANALYSIS_API_KEY: "aa-env",
      DESIGN_ARENA_API_KEY: "design-env",
    });
  });
});
