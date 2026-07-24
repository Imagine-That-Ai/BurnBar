import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
const ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../..",
);
const OWNED = [
  "docs/linux-port/P36_VISUAL_INTERACTION_POLISH_PROOF.md",
  "scripts/linux-port/lib/p36-visual-polish-proof.mjs",
  "scripts/linux-port/run-p36-native-visual-polish-probes.mjs",
  "scripts/linux-port/materialize-p36-visual-polish-session.mjs",
  "scripts/linux-port/capture-p36-visual-polish-proof.mjs",
  "scripts/linux-port/p36-visual-polish-proof.test.mjs",
  "scripts/linux-port/product-validators/P-36.mjs",
  "scripts/linux-port/ownership-tests/P-36.test.mjs",
];
test("P-36 standalone ownership is exact and fail closed", () => {
  for (const file of OWNED)
    assert.equal(fs.existsSync(path.join(ROOT, file)), true, `missing ${file}`);
  const found = [];
  for (const directory of [
    "docs/linux-port",
    "scripts/linux-port",
    "scripts/linux-port/lib",
    "scripts/linux-port/product-validators",
    "scripts/linux-port/ownership-tests",
  ])
    for (const name of fs.readdirSync(path.join(ROOT, directory)))
      if (/P-?36|p36/iu.test(name))
        found.push(
          path
            .relative(ROOT, path.join(ROOT, directory, name))
            .split(path.sep)
            .join("/"),
        );
  assert.deepEqual([...new Set(found)].sort(), [...OWNED].sort());
});
