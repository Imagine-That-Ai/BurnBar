import { afterEach, describe, expect, it } from "vitest";

import { sourceMetadata } from "../sourceMetadata.js";

const SOURCE_ENV_KEYS = ["OPENBURNBAR_SOURCE_COMMIT", "SOURCE_COMMIT", "GIT_SHA", "FUNCTION_VERSION"] as const;

afterEach(() => {
  for (const key of SOURCE_ENV_KEYS) {
    delete process.env[key];
  }
});

describe("sourceMetadata", () => {
  it("exposes AGPL corresponding-source metadata", () => {
    process.env.OPENBURNBAR_SOURCE_COMMIT = "unit-commit";
    const metadata = sourceMetadata();

    expect(metadata.license).toBe("AGPL-3.0-only");
    expect(metadata.source.repository).toBe("https://github.com/Imagine-That-Ai/BurnBar");
    expect(metadata.source.commit).toBe("unit-commit");
    expect(metadata.source.correspondingSource).toBe("https://burnbar.ai/legal/source");
  });

  it("does not treat a deploy version as source provenance", () => {
    process.env.FUNCTION_VERSION = "v2026.06.08.1200";

    expect(sourceMetadata().source.commit).toBe("unknown");
  });

  it("falls back only to explicit source commit variables", () => {
    process.env.SOURCE_COMMIT = "source-commit";
    process.env.GIT_SHA = "git-sha";
    process.env.FUNCTION_VERSION = "v2026.06.08.1200";

    expect(sourceMetadata().source.commit).toBe("source-commit");

    delete process.env.SOURCE_COMMIT;
    expect(sourceMetadata().source.commit).toBe("git-sha");
  });
});
