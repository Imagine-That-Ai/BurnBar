import { describe, expect, it, vi, beforeEach } from "vitest";

const resilientFetch = vi.fn(async () => new Response("{}"));

vi.mock("../resilienceHelpers.js", () => ({
  resilientFetch,
}));

describe("providerFetch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("delegates to resilientFetch with provider.operation label", async () => {
    const { providerFetch } = await import("../providers/httpClient.js");
    await providerFetch("openai", "models", "https://api.openai.com/v1/models");
    expect(resilientFetch).toHaveBeenCalledWith(
      "openai.models",
      "https://api.openai.com/v1/models",
      undefined,
    );
  });
});
