import assert from "node:assert/strict";
import test from "node:test";

import { sourceMetadata } from "./sourceMetadata.js";

test("sourceMetadata exposes AGPL corresponding-source metadata", () => {
  process.env.OPENBURNBAR_SOURCE_COMMIT = "hosted-mcp-unit";
  const metadata = sourceMetadata();

  assert.equal(metadata.license, "AGPL-3.0-only");
  assert.equal(metadata.source.repository, "https://github.com/Imagine-That-Ai/BurnBar");
  assert.equal(metadata.source.commit, "hosted-mcp-unit");
  assert.equal(metadata.source.correspondingSource, "https://burnbar.ai/legal/source");

  delete process.env.OPENBURNBAR_SOURCE_COMMIT;
});
