import { describe, expect, it } from "vitest";

import { requireOptionalSearchHashes, requireTokenHashes } from "../callables/shared.js";

describe("encrypted search hash validation", () => {
  it("rejects plaintext-like token and semantic hash entries", () => {
    expect(() => requireTokenHashes(["private prompt"], "chunk.tokenHashes")).toThrow(/invalid hash/);
    expect(() => requireOptionalSearchHashes(["not-a-valid-hash"], "chunk.semanticHashes")).toThrow(/invalid hash/);
  });

  it("keeps the full encrypted-search hash capacity at the callable boundary", () => {
    const hashes = Array.from({ length: 1_024 }, (_, index) => index.toString(16).padStart(32, "0"));
    expect(requireTokenHashes(hashes, "chunk.tokenHashes")).toHaveLength(1_024);
  });
});
