import { strict as assert } from "node:assert";
import test from "node:test";
import { internalLinks, sanitizeForLog, validateAgentsLinks } from "./validate-agents-md-links.mjs";

test("extracts only internal non-empty links", () => {
  const links = internalLinks(`
[Docs](docs/README.md)
[Section](docs/README.md#section)
[External](https://example.com)
[Anchor](#local)
`);
  assert.deepEqual(
    links.map((link) => link.path),
    ["docs/README.md", "docs/README.md"],
  );
});

test("reports broken links without executing workflow-command text", () => {
  const markdown = "[bad](missing.md\\n::error::owned)";
  const result = validateAgentsLinks(markdown, () => false);

  assert.equal(result.broken.length, 1);
  assert.equal(sanitizeForLog(result.broken[0].path), "missing.md\\n:\\:error:\\:owned");
});

test("keeps valid links separate from broken links", () => {
  const markdown = "[ok](docs/README.md) [bad](docs/MISSING.md)";
  const result = validateAgentsLinks(markdown, (path) => path === "docs/README.md");

  assert.deepEqual(
    result.ok.map((link) => link.path),
    ["docs/README.md"],
  );
  assert.deepEqual(
    result.broken.map((link) => link.path),
    ["docs/MISSING.md"],
  );
});

