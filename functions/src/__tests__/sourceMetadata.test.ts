import { describe, expect, it } from "vitest";

import { sourceMetadata } from "../sourceMetadata.js";

describe("sourceMetadata", () => {
  it("exposes AGPL corresponding-source metadata", () => {
    process.env.OPENBURNBAR_SOURCE_COMMIT = "unit-commit";
    const metadata = sourceMetadata();

    expect(metadata.license).toBe("AGPL-3.0-only");
    expect(metadata.source.repository).toBe("https://github.com/Imagine-That-Ai/BurnBar");
    expect(metadata.source.commit).toBe("unit-commit");
    expect(metadata.source.correspondingSource).toBe("https://burnbar.ai/legal/source");

    delete process.env.OPENBURNBAR_SOURCE_COMMIT;
  });
});
