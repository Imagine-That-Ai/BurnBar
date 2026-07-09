import { describe, expect, it, vi, beforeEach } from "vitest";

const providerResilientFetch = vi.fn(async () => new Response("{}"));

vi.mock("../resilienceHelpers.js", () => ({
  providerResilientFetch,
}));

describe("providerFetch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("delegates to providerResilientFetch with the provider key and operation label", async () => {
    const { providerFetch } = await import("../providers/httpClient.js");
    await providerFetch("openai", "models", "https://api.openai.com/v1/models");
    expect(providerResilientFetch).toHaveBeenCalledWith(
      "openai",
      "models",
      "https://api.openai.com/v1/models",
      undefined,
    );
  });
});
